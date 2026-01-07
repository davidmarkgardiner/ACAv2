# Holmes + AKS-MCP Demo Scenarios

Interactive demos where you break something and Holmes/AKS-MCP diagnoses and fixes it.

## Prerequisites

- Holmes deployed and running
- AKS-MCP deployed (optional, for az CLI commands)
- LiteLLM gateway running

## Scenario 1: OOMKilled Pod (Easy)

**Break it:**
```bash
# Deploy a memory-hungry pod that will get OOMKilled
kubectl create namespace demo
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: memory-hog
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: memory-hog
  template:
    metadata:
      labels:
        app: memory-hog
    spec:
      containers:
      - name: stress
        image: polinux/stress
        command: ["stress"]
        args: ["--vm", "1", "--vm-bytes", "500M", "--vm-hang", "1"]
        resources:
          limits:
            memory: "128Mi"
          requests:
            memory: "64Mi"
EOF

# Wait for it to crash
kubectl get pods -n demo -w
```

**Ask Holmes:**
```bash
curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "demo",
    "title": "Pod keeps restarting",
    "description": "The memory-hog pod in demo namespace keeps crashing with OOMKilled",
    "subject": {"name": "memory-hog", "namespace": "demo", "kind": "Deployment"},
    "context": {}
  }'
```

**Expected diagnosis:** Pod is being OOMKilled because memory limit (128Mi) is too low for workload (500M).

**Fix:**
```bash
kubectl set resources deployment/memory-hog -n demo --limits=memory=1Gi
```

**Cleanup:**
```bash
kubectl delete namespace demo
```

---

## Scenario 2: ImagePullBackOff (Medium)

**Break it:**
```bash
kubectl create namespace demo

# Deploy with a non-existent image tag
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bad-image
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: bad-image
  template:
    metadata:
      labels:
        app: bad-image
    spec:
      containers:
      - name: app
        image: nginx:this-tag-does-not-exist-12345
EOF

# Watch it fail
kubectl get pods -n demo -w
```

**Ask Holmes:**
```bash
curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "demo",
    "title": "Pod stuck in ImagePullBackOff",
    "description": "Deployment bad-image in demo namespace cannot start",
    "subject": {"name": "bad-image", "namespace": "demo", "kind": "Deployment"},
    "context": {}
  }'
```

**Expected diagnosis:** Image tag `this-tag-does-not-exist-12345` does not exist in registry.

**Fix:**
```bash
kubectl set image deployment/bad-image -n demo app=nginx:latest
```

**Cleanup:**
```bash
kubectl delete namespace demo
```

---

## Scenario 3: Service Misconfiguration (Medium)

**Break it:**
```bash
kubectl create namespace demo

# Deploy nginx
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: demo
spec:
  selector:
    app: wrong-label  # WRONG! Should be "web"
  ports:
  - port: 80
    targetPort: 80
EOF

# Test - this will fail
kubectl run curl --rm -it --image=curlimages/curl --restart=Never -n demo -- curl -s --max-time 5 http://web
```

**Ask Holmes:**
```bash
curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "demo",
    "title": "Service not working",
    "description": "Cannot connect to web service in demo namespace, curl times out",
    "subject": {"name": "web", "namespace": "demo", "kind": "Service"},
    "context": {}
  }'
```

**Expected diagnosis:** Service selector `app: wrong-label` doesn't match any pods. Pods have label `app: web`.

**Fix:**
```bash
kubectl patch svc web -n demo -p '{"spec":{"selector":{"app":"web"}}}'
```

**Cleanup:**
```bash
kubectl delete namespace demo
```

---

## Scenario 4: CrashLoopBackOff - Missing ConfigMap (Hard)

**Break it:**
```bash
kubectl create namespace demo

# Deploy app that requires a ConfigMap
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: config-app
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: config-app
  template:
    metadata:
      labels:
        app: config-app
    spec:
      containers:
      - name: app
        image: busybox
        command: ["sh", "-c", "cat /config/settings.conf && sleep 3600"]
        volumeMounts:
        - name: config
          mountPath: /config
      volumes:
      - name: config
        configMap:
          name: app-settings  # This ConfigMap doesn't exist!
EOF

# Watch it fail
kubectl get pods -n demo -w
```

**Ask Holmes:**
```bash
curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "demo",
    "title": "Pod cannot start",
    "description": "config-app deployment pods are stuck and cannot start",
    "subject": {"name": "config-app", "namespace": "demo", "kind": "Deployment"},
    "context": {}
  }'
```

**Expected diagnosis:** Pod references ConfigMap `app-settings` which doesn't exist.

**Fix:**
```bash
kubectl create configmap app-settings -n demo --from-literal=settings.conf="debug=true"
kubectl rollout restart deployment/config-app -n demo
```

**Cleanup:**
```bash
kubectl delete namespace demo
```

---

## Scenario 5: ResourceQuota Exceeded (Hard)

**Break it:**
```bash
kubectl create namespace demo

# Create restrictive ResourceQuota
kubectl apply -f - <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: demo-quota
  namespace: demo
spec:
  hard:
    pods: "2"
    requests.cpu: "500m"
    requests.memory: "512Mi"
EOF

# Try to deploy 5 replicas
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: quota-test
  namespace: demo
spec:
  replicas: 5
  selector:
    matchLabels:
      app: quota-test
  template:
    metadata:
      labels:
        app: quota-test
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        resources:
          requests:
            cpu: "200m"
            memory: "256Mi"
EOF

# Check - only 2 pods will be created
kubectl get pods -n demo
kubectl get events -n demo --sort-by='.lastTimestamp' | tail -10
```

**Ask Holmes:**
```bash
curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "demo",
    "title": "Deployment not scaling",
    "description": "quota-test deployment should have 5 replicas but only 2 are running",
    "subject": {"name": "quota-test", "namespace": "demo", "kind": "Deployment"},
    "context": {}
  }'
```

**Expected diagnosis:** ResourceQuota limits pods to 2 and CPU to 500m. Cannot create more pods.

**Fix options:**
```bash
# Option 1: Increase quota
kubectl patch resourcequota demo-quota -n demo -p '{"spec":{"hard":{"pods":"10","requests.cpu":"2"}}}'

# Option 2: Reduce resource requests
kubectl patch deployment quota-test -n demo -p '{"spec":{"template":{"spec":{"containers":[{"name":"nginx","resources":{"requests":{"cpu":"50m","memory":"64Mi"}}}]}}}}'
```

**Cleanup:**
```bash
kubectl delete namespace demo
```

---

## Testing Holmes API

### Port-forward to Holmes:
```bash
kubectl port-forward -n holmesgpt svc/holmesgpt-holmes 5050:80
```

### Simple health check:
```bash
curl http://localhost:5050/healthz
```

### Interactive investigation:
```bash
curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "manual",
    "title": "What pods are unhealthy?",
    "description": "Find any pods that are not running correctly in the cluster",
    "subject": {"name": "cluster", "namespace": "default", "kind": "Cluster"},
    "context": {}
  }'
```

### Stream response (for long investigations):
```bash
curl -N -X POST http://localhost:5050/api/stream/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "manual",
    "title": "Cluster health check",
    "description": "Check overall cluster health and report any issues",
    "subject": {"name": "cluster", "namespace": "default"},
    "context": {}
  }'
```

---

## Scenario 6: Kyverno Policy Blocking Deployment (Medium)

**Break it:**
```bash
kubectl create namespace demo

# Create a policy that requires labels
kubectl apply -f - <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-label
spec:
  validationFailureAction: Enforce
  rules:
  - name: check-team-label
    match:
      any:
      - resources:
          kinds:
          - Deployment
          namespaces:
          - demo
    validate:
      message: "Deployment must have 'team' label"
      pattern:
        metadata:
          labels:
            team: "?*"
EOF

# Try to deploy without the required label
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: no-label-app
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: no-label-app
  template:
    metadata:
      labels:
        app: no-label-app
    spec:
      containers:
      - name: nginx
        image: nginx:latest
EOF
# This will be DENIED by Kyverno!
```

**Ask Holmes:**
```bash
curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "demo",
    "title": "Deployment blocked by admission webhook",
    "description": "Cannot create deployment no-label-app in demo namespace, admission webhook denied",
    "subject": {"name": "no-label-app", "namespace": "demo", "kind": "Deployment"},
    "context": {}
  }'
```

**Expected diagnosis:** Kyverno policy `require-team-label` is blocking deployment due to missing `team` label.

**Fix:**
```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: no-label-app
  namespace: demo
  labels:
    team: platform  # Add required label
spec:
  replicas: 1
  selector:
    matchLabels:
      app: no-label-app
  template:
    metadata:
      labels:
        app: no-label-app
        team: platform
    spec:
      containers:
      - name: nginx
        image: nginx:latest
EOF
```

**Cleanup:**
```bash
kubectl delete clusterpolicy require-team-label
kubectl delete namespace demo
```

---

## Scenario 7: KRO Instance Stuck (Hard)

**Break it:**
```bash
# Apply a ResourceGraphDefinition with a bad readyWhen expression
kubectl apply -f - <<EOF
apiVersion: kro.run/v1alpha1
kind: ResourceGraphDefinition
metadata:
  name: demo-app
spec:
  schema:
    apiVersion: v1alpha1
    kind: DemoApp
    spec:
      name: string | default=demo
      namespace: string | default=demo
    status:
      ready: \${deployment.status.availableReplicas}
  resources:
    - id: ns
      template:
        apiVersion: v1
        kind: Namespace
        metadata:
          name: \${schema.spec.namespace}
    - id: deployment
      readyWhen:
        # This will fail because status.availableReplicas doesn't exist initially
        - \${deployment.status.availableReplicas == 1}
      template:
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: \${schema.spec.name}
          namespace: \${schema.spec.namespace}
        spec:
          replicas: 1
          selector:
            matchLabels:
              app: demo
          template:
            metadata:
              labels:
                app: demo
            spec:
              containers:
              - name: nginx
                image: nginx:nonexistent-tag-12345  # Bad image!
EOF

# Create an instance
kubectl apply -f - <<EOF
apiVersion: kro.run/v1alpha1
kind: DemoApp
metadata:
  name: my-demo
  namespace: kro
spec:
  name: demo
  namespace: demo
EOF

# Check status - will be stuck
kubectl get demoapp -n kro
kubectl get holmes my-demo -n kro -o jsonpath='{.status.conditions}' | jq .
```

**Ask Holmes:**
```bash
curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "demo",
    "title": "KRO instance not ready",
    "description": "DemoApp my-demo in kro namespace is stuck in ERROR state",
    "subject": {"name": "my-demo", "namespace": "kro", "kind": "DemoApp"},
    "context": {}
  }'
```

**Expected diagnosis:**
1. readyWhen expression fails because deployment status fields don't exist yet
2. Deployment pod has ImagePullBackOff due to bad image tag

**Fix:**
```bash
# Fix the deployment image
kubectl set image deployment/demo -n demo nginx=nginx:latest
```

**Cleanup:**
```bash
kubectl delete demoapp my-demo -n kro
kubectl delete resourcegraphdefinition demo-app
kubectl delete namespace demo
```

---

## Scenario 8: External Secrets Not Syncing (Hard - requires Key Vault)

**Note:** This requires an Azure Key Vault and Workload Identity setup.

**Break it:**
```bash
kubectl create namespace demo

# Create ClusterSecretStore pointing to wrong vault
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: demo-vault
spec:
  provider:
    azurekv:
      authType: WorkloadIdentity
      vaultUrl: "https://nonexistent-vault-12345.vault.azure.net"
      serviceAccountRef:
        name: external-secrets
        namespace: external-secrets
EOF

# Create ExternalSecret
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: demo-secret
  namespace: demo
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: demo-vault
    kind: ClusterSecretStore
  target:
    name: my-secret
  data:
  - secretKey: password
    remoteRef:
      key: my-password
EOF

# Check - will show SecretSyncedError
kubectl get externalsecret -n demo
kubectl describe externalsecret demo-secret -n demo
```

**Ask Holmes:**
```bash
curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "demo",
    "title": "ExternalSecret not syncing",
    "description": "ExternalSecret demo-secret in demo namespace shows SecretSyncedError",
    "subject": {"name": "demo-secret", "namespace": "demo", "kind": "ExternalSecret"},
    "context": {}
  }'
```

**Expected diagnosis:**
- ClusterSecretStore references non-existent Key Vault
- Or Workload Identity not configured for ESO ServiceAccount
- Or UAMI missing Key Vault access policy

**Cleanup:**
```bash
kubectl delete externalsecret demo-secret -n demo
kubectl delete clustersecretstore demo-vault
kubectl delete namespace demo
```
