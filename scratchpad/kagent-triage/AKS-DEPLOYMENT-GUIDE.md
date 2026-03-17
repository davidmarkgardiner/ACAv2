# AKS Cluster Deployment Guide for kagent Triage

Step-by-step process for spinning up an AKS cluster, deploying the kagent triage stack, testing agents, and shutting down.

**Authorization required** — never deploy Azure resources without explicit approval from the repo owner.

---

## Prerequisites

- Access to `kind-argo-workflow` kubectl context (ASO management plane)
- Azure CLI authenticated (`az login`)
- Kimi API key (or alternative LLM provider)

## Step 1: Deploy the AKS Cluster

Use the `uk8scluster-public` ResourceGraphDefinition — it has security defaults (local accounts disabled, Azure RBAC, Defender, Istio).

```bash
# Switch to the ASO management plane
kubectx kind-argo-workflow

# Review the RGD
cat infra-stack/kro-stack/definitions/uk8scluster-public.yaml

# Create the cluster instance (EDIT values first)
kubectl apply -f - <<'EOF'
apiVersion: kro.run/v1alpha1
kind: UK8SCluster
metadata:
  name: aks-event-triage-dev
  namespace: uk8s-nextgen
spec:
  clusterName: aks-event-triage-dev
  location: uksouth
  ownerResourceGroup: rg-event-triage-dev
  kubernetesVersion: "1.32"
  nodePool:
    count: 1
    vmSize: Standard_B4ms
  tags:
    environment: dev
    managed-by: kro
    project: event-triage
  # ... see uk8scluster-public.yaml for full spec
EOF

# Watch provisioning (~10 min)
kubectl get akscluster -n uk8s-nextgen -w
```

## Step 2: Get Credentials

```bash
# Azure AD auth (default — local accounts disabled)
az aks get-credentials -g rg-event-triage-dev -n aks-event-triage-dev

# If you need admin access (enable local accounts first)
az aks update -g rg-event-triage-dev -n aks-event-triage-dev --enable-local-accounts --yes
az aks get-credentials -g rg-event-triage-dev -n aks-event-triage-dev --admin

# Verify
kubectl --context aks-event-triage-dev-admin get ns
```

## Step 3: Deploy Argo Workflows + Events

```bash
AKS=aks-event-triage-dev-admin

# Argo Workflows
helm install argo-workflows argo/argo-workflows \
  --namespace argo --create-namespace \
  --kube-context $AKS \
  --set 'server.extraArgs={--auth-mode=server}' \
  --wait --timeout 5m

# Argo Events
kubectl --context $AKS create namespace argo-events
kubectl --context $AKS apply -f https://raw.githubusercontent.com/argoproj/argo-events/v1.9.6/manifests/install.yaml -n argo-events

# EventBus (NATS 3-replica)
kubectl --context $AKS apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: EventBus
metadata:
  name: default
  namespace: argo-events
spec:
  nats:
    native:
      replicas: 3
      auth: token
EOF

# RBAC — give Argo Events cluster-admin (for dev/test only)
kubectl --context $AKS apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argo-events-sa
  namespace: argo-events
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argo-events-controller-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: argo-events-sa
    namespace: argo-events
  - kind: ServiceAccount
    name: default
    namespace: argo-events
EOF

# EventSource (cluster-wide K8s warning events)
kubectl --context $AKS apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: k8s-warning-events
  namespace: argo-events
spec:
  resource:
    warning-events:
      namespace: ""
      group: ""
      version: v1
      resource: events
      eventTypes:
        - ADD
      filter:
        fields:
          - key: type
            operation: "=="
            value: Warning
EOF

# WorkflowTemplate
kubectl --context $AKS apply -f kagent-triage/02-workflow-kagent-triage.yaml

# Wait for everything
kubectl --context $AKS wait --for=condition=Ready pod -l eventbus-name=default -n argo-events --timeout=120s
kubectl --context $AKS get pods -n argo -n argo-events
```

## Step 4: Deploy kagent + LiteLLM

```bash
AKS=aks-event-triage-dev-admin

# Create kagent namespace
kubectl --context $AKS create namespace kagent

# Export CRDs from Kind cluster (kagent Helm chart is OCI-gated)
kubectl --context red get crd agents.kagent.dev -o json | \
  python3 -c "
import json, sys
d = json.load(sys.stdin)
for k in ['uid','resourceVersion','creationTimestamp','generation','managedFields']:
    d['metadata'].pop(k, None)
json.dump(d, sys.stdout)
" | kubectl --context $AKS apply --server-side --force-conflicts -f -

# Export remaining CRDs
helm --kube-context red get manifest kagent-crds -n kagent | kubectl --context $AKS apply -f -

# Export kagent controller manifests
helm --kube-context red get manifest kagent -n kagent | kubectl --context $AKS apply -f -

# Create LiteLLM config + secrets
kubectl --context $AKS apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: litellm-config
  namespace: kagent
data:
  config.yaml: |
    model_list:
      - model_name: kimi-for-coding
        litellm_params:
          model: openai/kimi-for-coding
          api_key: os.environ/KIMI_API_KEY
          api_base: https://api.kimi.com/coding/v1
          extra_headers:
            User-Agent: "claude-code/1.0"
          extra_body:
            thinking:
              type: disabled
          merge_reasoning_content_in_choices: true
    litellm_settings:
      drop_params: true
      modify_params: true
      num_retries: 2
    general_settings:
      master_key: sk-litellm-kimi-1234
---
apiVersion: v1
kind: Secret
metadata:
  name: kimi-api-secret
  namespace: kagent
stringData:
  KIMI_API_KEY: "<YOUR_KIMI_API_KEY>"
---
apiVersion: v1
kind: Secret
metadata:
  name: kagent-openai
  namespace: kagent
stringData:
  OPENAI_API_KEY: "sk-litellm-kimi-1234"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: litellm-proxy
  namespace: kagent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: litellm-proxy
  template:
    metadata:
      labels:
        app: litellm-proxy
    spec:
      containers:
      - name: litellm
        image: ghcr.io/berriai/litellm:main-latest
        ports:
        - containerPort: 4000
        env:
        - name: KIMI_API_KEY
          valueFrom:
            secretKeyRef:
              name: kimi-api-secret
              key: KIMI_API_KEY
        args: ["--config", "/app/config.yaml", "--port", "4000"]
        volumeMounts:
        - name: config
          mountPath: /app/config.yaml
          subPath: config.yaml
        resources:
          requests:
            cpu: 100m
            memory: 512Mi
          limits:
            cpu: 500m
            memory: 1Gi
      volumes:
      - name: config
        configMap:
          name: litellm-config
---
apiVersion: v1
kind: Service
metadata:
  name: litellm-proxy
  namespace: kagent
spec:
  selector:
    app: litellm-proxy
  ports:
  - port: 4000
    targetPort: 4000
EOF

# Update ModelConfig to point at LiteLLM
kubectl --context $AKS patch modelconfig default-model-config -n kagent --type=merge -p '{
  "spec": {
    "model": "kimi-for-coding",
    "provider": "OpenAI",
    "openAI": {
      "baseUrl": "http://litellm-proxy.kagent:4000/v1"
    }
  }
}'

# Wait for pods
kubectl --context $AKS get pods -n kagent -w
```

## Step 5: Deploy Agents + Sensors

```bash
AKS=aks-event-triage-dev-admin

# Deploy AKS namespace agents
cd kagent-triage/aks
./deploy-all.sh $AKS

# Wait for agents to be ready
kubectl --context $AKS wait agent --all -n kagent --for=condition=Ready --timeout=120s

# Verify
kubectl --context $AKS get agents -n kagent
kubectl --context $AKS get sensors -n argo-events
```

## Step 6: Smoke Test (1 Call Only)

```bash
AKS=aks-event-triage-dev-admin

cat <<'SCRIPT' | kubectl --context $AKS run smoke-test --image=python:3.11-slim --rm -i --restart=Never -n kagent -- python3
import json, urllib.request, sys
base = "http://kagent-controller.kagent:8083"
payload = json.dumps({
    "jsonrpc": "2.0", "id": "smoke-1",
    "method": "message/send",
    "params": {"message": {"role": "user", "parts": [{"kind": "text", "text": "Check health of all pods in flux-system namespace."}]}}
}).encode()
req = urllib.request.Request(f"{base}/api/a2a/kagent/flux-system-agent/", data=payload,
    headers={"Content-Type": "application/json"}, method="POST")
try:
    with urllib.request.urlopen(req, timeout=300) as r:
        result = json.loads(r.read().decode())
        status = result.get("result", {}).get("status", {}).get("state", "unknown")
        for a in result.get("result", {}).get("artifacts", []):
            for p in a.get("parts", []):
                if p.get("text"): print(p["text"][:1500])
        print(f"\nStatus: {status}", file=sys.stderr)
except Exception as e:
    print(f"Error: {e}")
SCRIPT
```

## Step 7: Shut Down When Done

```bash
# Option A: Stop the cluster (keeps config, stops billing for compute)
az aks stop -g rg-event-triage-dev -n aks-event-triage-dev

# Option B: Delete via KRO (removes everything including Azure resources)
kubectx kind-argo-workflow
kubectl delete akscluster aks-event-triage-dev -n uk8s-nextgen

# Option C: Delete the entire resource group
az group delete -g rg-event-triage-dev --yes --no-wait
```

---

## Known Issues

| Issue | Workaround |
|-------|-----------|
| Local accounts disabled by default | `az aks update --enable-local-accounts` for admin access |
| Argo Events controller needs leases RBAC | Grant cluster-admin to argo-events SA (dev only) |
| LiteLLM OOMKilled at 512Mi | Set memory limit to 1Gi |
| Agent CRD too large for kubectl apply | Use `--server-side --force-conflicts` |
| Karpenter may take 2-3 min to scale nodes | Wait for pods, don't retry immediately |
| Kimi API rate limiting after ~10 calls | Space tests apart, use 1 call per agent |
| Sensor cascade from PolicyViolation events | Filter `reason != PolicyViolation` in sensors |
| kube-system extremely noisy | Rate limit to 2/min or remove sensor |

## LiteLLM → Kimi Configuration

| Setting | Value |
|---------|-------|
| Kimi endpoint | `https://api.kimi.com/coding/v1` |
| LiteLLM internal URL | `http://litellm-proxy.kagent:4000/v1` |
| LiteLLM master key | `sk-litellm-kimi-1234` |
| Model name | `kimi-for-coding` |
| User-Agent header | `claude-code/1.0` (required by Kimi — LiteLLM adds it) |
| Flow | kagent → LiteLLM (OpenAI-compatible) → Kimi API |

## Files Reference

| Path | Purpose |
|------|---------|
| `kagent-triage/aks/` | AKS namespace agent + sensor YAMLs |
| `kagent-triage/aks/deploy-all.sh` | Deploy all agents and sensors |
| `kagent-triage/02-workflow-kagent-triage.yaml` | Shared WorkflowTemplate (A2A + Logic App) |
| `kagent-triage/logic-app/` | Azure Logic App for Teams notifications |
| `kagent-triage/HANDOVER-2026-03-16.md` | Full session handover |
| `infra-stack/kro-stack/definitions/uk8scluster-public.yaml` | Standard RGD for AKS clusters |

## Tested Agents

### Kind Cluster (context: red)
| Agent | Namespace | Result |
|-------|-----------|--------|
| cert-manager-agent | cert-manager | 7/7 PASS |
| external-secrets-agent | external-secrets | 7/7 PASS |
| kro-agent | kro-system | 7/7 PASS |
| kyverno-agent | kyverno | 7/7 PASS |
| reloader-agent | reloader | 7/7 PASS |

### AKS Cluster (context: aks-event-triage-dev-admin)
| Agent | Namespace | Result |
|-------|-----------|--------|
| flux-system-agent | flux-system | PASS — listed pods, identified node drain |
| aks-istio-system-agent | aks-istio-system | Deployed, Kimi rate limited |
| aks-istio-ingress-agent | aks-istio-ingress | Deployed, Kimi rate limited |
| gatekeeper-system-agent | gatekeeper-system | Deployed, Kimi rate limited |
| kube-system-agent | kube-system | Deployed, Kimi rate limited |
